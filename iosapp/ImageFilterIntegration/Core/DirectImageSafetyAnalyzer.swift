import CoreGraphics
import ImageIO
import Foundation
import UIKit

public nonisolated struct PurelineMobileCLIPEvidence: Equatable, Sendable {
    public let source: String
    public let woman: Double
    public let man: Double
    public let uncertain: Double
    public init(source: String, woman: Double, man: Double, uncertain: Double) {
        self.source = source; self.woman = woman; self.man = man; self.uncertain = uncertain
    }
}

public nonisolated struct PurelineNudeNetEvidence: Equatable, Sendable {
    public let label: String
    public let confidence: Double
    public init(label: String, confidence: Double) { self.label = label; self.confidence = confidence }
}

public nonisolated enum PurelineImageSafetyPolicy {
    public static func mobileCLIPBlocks(_ evidence: PurelineMobileCLIPEvidence, policy: PurelineFilterConfiguration.MobileCLIP2Policy) -> Bool {
        let threshold: Double
        switch evidence.source {
        case "faceFallback": threshold = policy.faceFallbackWomanMinScore
        case "wholeImageFallback": threshold = policy.wholeImageFallbackWomanMinScore
        default: threshold = policy.womanMinScore
        }
        return evidence.woman >= policy.blockWomanWithoutMarginIfScoreAtLeast
            || (evidence.woman >= threshold && evidence.woman - evidence.man >= policy.womanMinMarginOverMan)
            || evidence.uncertain >= policy.uncertainMinScore
    }

    public static func nudeNetBlocks(_ evidence: PurelineNudeNetEvidence, thresholds: [String: Double]) -> Bool {
        guard let threshold = thresholds[evidence.label] else { return false }
        return evidence.confidence >= threshold
    }

    public static func blocks(mobileCLIP: [PurelineMobileCLIPEvidence], nudeNet: [PurelineNudeNetEvidence], configuration: PurelineFilterConfiguration) -> Bool {
        mobileCLIP.contains { mobileCLIPBlocks($0, policy: configuration.mobileCLIP2Policy) }
            || nudeNet.contains { nudeNetBlocks($0, thresholds: configuration.nudeNet.thresholds) }
    }
}

/// A cancellation-safe, retryable single-flight gate for expensive model load.
public actor PurelineModelLifecycle {
    public enum State: String, Sendable { case unloaded, preparing, ready }
    private let operation: @Sendable () async throws -> Void
    private var task: Task<Void, Error>?
    private var state: State = .unloaded
    private var attempts = 0
    private var completions = 0

    public init(operation: @escaping @Sendable () async throws -> Void) { self.operation = operation }

    @discardableResult
    public func prepareIfNeeded() async throws -> Bool {
        if state == .ready { return false }
        if let task { try await task.value; return false }
        attempts += 1
        state = .preparing
        let operation = self.operation
        let created = Task { try await operation() }
        task = created
        do {
            try await created.value
            task = nil; state = .ready; completions += 1
            return true
        } catch {
            task = nil; state = .unloaded
            throw error
        }
    }

    public func snapshot() -> (state: State, attempts: Int, completions: Int) { (state, attempts, completions) }
}

public nonisolated enum DirectImageSafetyError: Error {
    case invalidImage
    case unsupportedImage
    case modelUnavailable(String)
}

public nonisolated struct DirectImageSafetyDecision: Sendable {
    public let allowed: Bool
    public let risk: String
    public let confidence: Double
    public let triggeredClass: String?
    public let personCount: Int
    public let highestWomanScore: Float?
    public let modelsRun: [String]
    public let modelsPrepared: [String]

    public init(allowed: Bool, risk: String, confidence: Double, triggeredClass: String?, personCount: Int,
                highestWomanScore: Float?, modelsRun: [String] = [], modelsPrepared: [String] = []) {
        self.allowed = allowed; self.risk = risk; self.confidence = confidence
        self.triggeredClass = triggeredClass; self.personCount = personCount
        self.highestWomanScore = highestWomanScore; self.modelsRun = modelsRun; self.modelsPrepared = modelsPrepared
    }
}

/// Decode directly into the configured raster budget. Resizing a UIImage after
/// decoding it can already have allocated the entire original inside the tunnel.
nonisolated enum PurelineImageDecoder {
    static func frameCount(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    static func decode(_ data: Data, pipeline: PurelineFilterConfiguration.Pipeline) -> CGImage? {
        guard !data.isEmpty, data.count <= pipeline.maximumImageBytes,
              pipeline.maximumPixelDimension > 0, pipeline.maximumTotalPixels > 0,
              let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthValue = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightValue = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let width = widthValue.doubleValue, height = heightValue.doubleValue
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let longestSide = max(width, height)
        let dimensionScale = min(1, Double(pipeline.maximumPixelDimension) / longestSide)
        let pixelScale = min(1, sqrt(Double(pipeline.maximumTotalPixels) / (width * height)))
        let thumbnailSize = max(1, Int((longestSide * min(dimensionScale, pixelScale)).rounded(.down)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              max(image.width, image.height) <= pipeline.maximumPixelDimension,
              image.width <= pipeline.maximumTotalPixels / max(1, image.height) else { return nil }
        return image
    }
}

/// Pureline-owned bounded facade over vendor detector/model services. The vendor
/// evidence pipeline and UI remain unchanged; PacketTunnel opts into this policy.
public actor DirectImageSafetyAnalyzer {
    public static let shared = DirectImageSafetyAnalyzer()
    public nonisolated static let packetTunnelUsesMobileCLIP = true
    public nonisolated static let packetTunnelUsesNudeNet = true

    private let humanDetector = PurelineHumanDetectionService()
    private let mobileCLIP: MobileCLIPService
    private let nudeNet: NudeNetService
    private let mobileLifecycle: PurelineModelLifecycle
    private let nudeLifecycle: PurelineModelLifecycle
    private var configuration = PurelineFilterConfiguration.builtIn
    private var revisionHash = "built-in"

    public init() {
        let mobile = MobileCLIPService.shared
        let nude = NudeNetService.shared
        mobileCLIP = mobile; nudeNet = nude
        mobileLifecycle = PurelineModelLifecycle { try await mobile.loadIfNeeded() }
        nudeLifecycle = PurelineModelLifecycle { try await nude.warmUp() }
    }

    public func apply(configuration: PurelineFilterConfiguration, revisionHash: String) {
        self.configuration = configuration
        self.revisionHash = revisionHash
    }

    public func activeRevisionHash() -> String { revisionHash }

    public func prepare() async { _ = try? await prepareIfNeeded() }

    @discardableResult
    public func prepareIfNeeded() async throws -> Bool {
        var prepared = false
        if configuration.enabled && configuration.models.mobileCLIP2 {
            prepared = try await mobileLifecycle.prepareIfNeeded() || prepared
        }
        if configuration.enabled && configuration.models.nudeNet {
            prepared = try await nudeLifecycle.prepareIfNeeded() || prepared
        }
        return prepared
    }

    public func preparationAttemptCount() async -> Int {
        let mobile = await mobileLifecycle.snapshot()
        let nude = await nudeLifecycle.snapshot()
        return mobile.attempts + nude.attempts
    }

    public func modelLifecycleSnapshots() async -> (mobileCLIP: (PurelineModelLifecycle.State, Int, Int), nudeNet: (PurelineModelLifecycle.State, Int, Int)) {
        let mobile = await mobileLifecycle.snapshot(), nude = await nudeLifecycle.snapshot()
        return ((mobile.state, mobile.attempts, mobile.completions), (nude.state, nude.attempts, nude.completions))
    }

    public func classify(imageData: Data, mimeType: String) async throws -> DirectImageSafetyDecision {
        _ = mimeType
        let config = configuration
        guard config.enabled, config.models.mobileCLIP2 || config.models.nudeNet else {
            return DirectImageSafetyDecision(allowed: true, risk: "disabled", confidence: 0,
                                             triggeredClass: nil, personCount: 0, highestWomanScore: nil)
        }
        guard imageData.count <= config.pipeline.maximumImageBytes else { throw DirectImageSafetyError.invalidImage }
        // The local runtime has no all-frame classifier. Approving frame zero
        // would expose uninspected animation frames to the browser.
        guard PurelineImageDecoder.frameCount(imageData) <= 1 else { throw DirectImageSafetyError.unsupportedImage }
        guard let decoded = PurelineImageDecoder.decode(imageData, pipeline: config.pipeline) else {
            throw DirectImageSafetyError.invalidImage
        }

        var detections: [HumanDetection] = []
        var crops: [PersonCrop] = []
        if config.personDetection.enabled && (config.models.mobileCLIP2 || (config.models.nudeNet && config.nudeNet.runPersonCrops)) {
            detections = try humanDetector.detect(in: decoded, orientation: .up)
            if detections.isEmpty && config.personDetection.useFaceFallback {
                detections = try humanDetector.detectFaces(in: decoded, orientation: .up)
            }
            if detections.isEmpty && config.personDetection.useWholeImageFallback {
                detections = [HumanDetection(id: UUID(), confidence: 0, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), source: .wholeImageFallback)]
            }
            let selected = detections.sorted {
                ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
            }.prefix(config.personDetection.maximumPersonCrops)
            let cropper = PersonCropService(
                horizontalPaddingFraction: CGFloat(config.personDetection.horizontalCropPadding),
                verticalPaddingFraction: CGFloat(config.personDetection.verticalCropPadding)
            )
            crops = selected.compactMap { cropper.crop(image: decoded, detection: $0) }
        }

        var modelsRun: [String] = [], modelsPrepared: [String] = []
        var mobileEvidence: [PurelineMobileCLIPEvidence] = []
        if config.models.mobileCLIP2 {
            do {
                if try await mobileLifecycle.prepareIfNeeded() { modelsPrepared.append("MobileCLIP2-S2") }
            } catch { throw DirectImageSafetyError.modelUnavailable("MobileCLIP2-S2") }
            modelsRun.append("MobileCLIP2-S2")
            for crop in crops {
                let result = try await mobileCLIP.classify(crop)
                let evidence = PurelineMobileCLIPEvidence(
                    source: result.detectionSource.rawValue, woman: Double(result.scores.woman),
                    man: Double(result.scores.man), uncertain: Double(result.scores.uncertain)
                )
                mobileEvidence.append(evidence)
                if config.pipeline.shortCircuitOnBlock,
                   PurelineImageSafetyPolicy.mobileCLIPBlocks(evidence, policy: config.mobileCLIP2Policy) {
                    return decision(mobileEvidence: mobileEvidence, nudeEvidence: [], people: detections.count,
                                    modelsRun: modelsRun, modelsPrepared: modelsPrepared, config: config)
                }
            }
        }

        var nudeEvidence: [PurelineNudeNetEvidence] = []
        if config.models.nudeNet {
            do {
                if try await nudeLifecycle.prepareIfNeeded() { modelsPrepared.append("NudeNet320n") }
            } catch { throw DirectImageSafetyError.modelUnavailable("NudeNet320n") }
            modelsRun.append("NudeNet320n")
            if config.nudeNet.runFullImage {
                let batch = try await nudeNet.detect(image: UIImage(cgImage: decoded))
                nudeEvidence.append(contentsOf: batch.detections.map { .init(label: $0.label, confidence: $0.confidence) })
            }
            if !config.pipeline.shortCircuitOnBlock || !nudeEvidence.contains(where: { PurelineImageSafetyPolicy.nudeNetBlocks($0, thresholds: config.nudeNet.thresholds) }) {
                if config.nudeNet.runPersonCrops {
                    for crop in crops {
                        let batch = try await nudeNet.detect(image: UIImage(cgImage: crop.image))
                        nudeEvidence.append(contentsOf: batch.detections.map { .init(label: $0.label, confidence: $0.confidence) })
                        if config.pipeline.shortCircuitOnBlock,
                           nudeEvidence.contains(where: { PurelineImageSafetyPolicy.nudeNetBlocks($0, thresholds: config.nudeNet.thresholds) }) { break }
                    }
                }
            }
        }
        return decision(mobileEvidence: mobileEvidence, nudeEvidence: nudeEvidence, people: detections.count,
                        modelsRun: modelsRun, modelsPrepared: modelsPrepared, config: config)
    }

    private func decision(mobileEvidence: [PurelineMobileCLIPEvidence], nudeEvidence: [PurelineNudeNetEvidence],
                          people: Int, modelsRun: [String], modelsPrepared: [String],
                          config: PurelineFilterConfiguration) -> DirectImageSafetyDecision {
        let mobileTrigger = mobileEvidence.first { PurelineImageSafetyPolicy.mobileCLIPBlocks($0, policy: config.mobileCLIP2Policy) }
        let nudeTrigger = nudeEvidence.filter { PurelineImageSafetyPolicy.nudeNetBlocks($0, thresholds: config.nudeNet.thresholds) }
            .max { $0.confidence < $1.confidence }
        let blocked = mobileTrigger != nil || nudeTrigger != nil
        let woman = mobileEvidence.map(\.woman).max()
        return DirectImageSafetyDecision(
            allowed: !blocked, risk: nudeTrigger != nil ? "nudity" : (mobileTrigger != nil ? "person-policy" : "none"),
            confidence: nudeTrigger?.confidence ?? mobileTrigger?.woman ?? 0,
            triggeredClass: nudeTrigger?.label ?? (mobileTrigger == nil ? nil : "MobileCLIP2"),
            personCount: people, highestWomanScore: woman.map(Float.init),
            modelsRun: modelsRun, modelsPrepared: modelsPrepared
        )
    }

}
