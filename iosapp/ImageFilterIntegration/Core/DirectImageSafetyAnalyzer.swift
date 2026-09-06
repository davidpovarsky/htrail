import Foundation

/// Public, extension-safe facade over the exact image-safety pipeline vendored
/// from AI-Image-Classifier. This is the direct bridge used by HTTrail's proxy;
/// it deliberately bypasses the loopback HTTP server while running the same
/// MobileCLIP2 + NudeNet pipeline.
public struct DirectImageSafetyDecision: Sendable {
    public let allowed: Bool
    public let risk: String
    public let confidence: Double
    public let triggeredClass: String?
    public let personCount: Int
    public let highestWomanScore: Float?

    public init(
        allowed: Bool,
        risk: String,
        confidence: Double,
        triggeredClass: String?,
        personCount: Int,
        highestWomanScore: Float?
    ) {
        self.allowed = allowed
        self.risk = risk
        self.confidence = confidence
        self.triggeredClass = triggeredClass
        self.personCount = personCount
        self.highestWomanScore = highestWomanScore
    }
}

public actor DirectImageSafetyAnalyzer {
    public static let shared = DirectImageSafetyAnalyzer()

    private let pipeline = ImageSafetyPipelineService.shared
    private let nudityPolicy = NudityFilterPolicy()

    public init() {}

    /// Loads the same two models used by the original app. Callers may choose to
    /// defer this until the first intercepted image to avoid changing the Packet
    /// Tunnel's baseline memory footprint while direct filtering is disabled.
    public func prepare() async {
        await pipeline.prepare()
    }

    /// Runs the complete original image-safety pipeline. The current blocking
    /// decision intentionally uses the classifier app's existing standard
    /// NudeNet policy only; MobileCLIP2 still runs and its evidence is returned,
    /// but no new woman-score threshold is invented by the integration layer.
    public func classify(imageData: Data, mimeType: String) async throws -> DirectImageSafetyDecision {
        let response = try await pipeline.classify(
            imageData: imageData,
            mimeType: mimeType,
            requestID: UUID()
        )

        let detections = response.nudity.mergedDetections.map { detection in
            NudeDetection(
                classId: NudeNetLabels.classId(for: detection.rawLabel) ?? -1,
                label: detection.rawLabel,
                confidence: detection.confidence,
                boundingBox: detection.boundingBox
            )
        }
        let policy = nudityPolicy.evaluate(detections)

        return DirectImageSafetyDecision(
            allowed: policy.allowed,
            risk: policy.risk,
            confidence: policy.confidence,
            triggeredClass: policy.triggeredClass,
            personCount: response.summary.personCount,
            highestWomanScore: response.summary.highestWomanScore
        )
    }
}
