import Foundation

/// Public, extension-safe facade over the exact image-safety pipeline vendored
/// from AI-Image-Classifier. The Packet Tunnel's current block decision is the
/// vendor NudeNet policy, so this facade deliberately avoids loading MobileCLIP.
/// The main app continues to use the vendor's complete pipeline unchanged.
public nonisolated struct DirectImageSafetyDecision: Sendable {
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
    public nonisolated static let packetTunnelUsesMobileCLIP = false
    public nonisolated static let packetTunnelUsesNudeNet = true

    private let nudeNet = NudeNetService.shared
    private let nudityPolicy = NudityFilterPolicy()
    private var prepared = false

    public init() {}

    /// Prepares only NudeNet. PacketTunnel never calls this while direct filtering
    /// is disabled and otherwise defers it until the first inspectable image.
    public func prepare() async {
        try? await prepareIfNeeded()
    }

    @discardableResult
    public func prepareIfNeeded() async throws -> Bool {
        guard !prepared else { return false }
        try await nudeNet.warmUp()
        prepared = true
        return true
    }

    /// Runs the exact vendor NudeNet detector and standard policy. The actor and
    /// NudeNet service serialize expensive inference.
    public func classify(imageData: Data, mimeType: String) async throws -> DirectImageSafetyDecision {
        _ = mimeType
        try await prepareIfNeeded()
        let batch = try await nudeNet.detect(imageData: imageData)
        let policy = nudityPolicy.evaluate(batch.detections)

        return DirectImageSafetyDecision(
            allowed: policy.allowed,
            risk: policy.risk,
            confidence: policy.confidence,
            triggeredClass: policy.triggeredClass,
            personCount: 0,
            highestWomanScore: nil
        )
    }
}
