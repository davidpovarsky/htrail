import CryptoKit
import Foundation

public nonisolated struct PurelineFilterConfiguration: Codable, Equatable, Sendable {
    public struct Models: Codable, Equatable, Sendable {
        public var mobileCLIP2: Bool
        public var nudeNet: Bool
    }

    public struct PersonDetection: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var useFaceFallback: Bool
        public var useWholeImageFallback: Bool
        public var maximumPersonCrops: Int
        public var horizontalCropPadding: Double
        public var verticalCropPadding: Double
    }

    public struct MobileCLIP2Policy: Codable, Equatable, Sendable {
        public var womanMinScore: Double
        public var womanMinMarginOverMan: Double
        public var faceFallbackWomanMinScore: Double
        public var wholeImageFallbackWomanMinScore: Double
        public var uncertainMinScore: Double
        public var blockWomanWithoutMarginIfScoreAtLeast: Double
    }

    public struct NudeNet: Codable, Equatable, Sendable {
        public var runFullImage: Bool
        public var runPersonCrops: Bool
        public var thresholds: [String: Double]
    }

    public struct Pipeline: Codable, Equatable, Sendable {
        public var shortCircuitOnBlock: Bool
        public var maximumImageBytes: Int
        public var maximumPixelDimension: Int
        public var maximumTotalPixels: Int
    }

    public enum OverflowAction: String, Codable, Sendable { case failOpen }
    public struct Runtime: Codable, Equatable, Sendable {
        public var maxConcurrentInference: Int
        public var maxConcurrentImageInspections: Int
        public var maxQueuedImageInspections: Int
        public var inspectionQueueOverflowAction: OverflowAction
        public var minimumAvailableMemoryBytes: UInt64
    }

    public enum FailureAction: String, Codable, Sendable { case failOpen, block }
    public struct FailurePolicy: Codable, Equatable, Sendable {
        public var classifierError: FailureAction
        public var modelUnavailable: FailureAction
        public var imageTooLarge: FailureAction
        public var memoryPressure: FailureAction
        public var unsupportedEncoding: FailureAction
    }

    public var schemaVersion: Int
    public var name: String
    public var enabled: Bool
    public var models: Models
    public var personDetection: PersonDetection
    public var mobileCLIP2Policy: MobileCLIP2Policy
    public var nudeNet: NudeNet
    public var pipeline: Pipeline
    public var runtime: Runtime
    public var failurePolicy: FailurePolicy

    public static let builtIn = PurelineFilterConfiguration(
        schemaVersion: 1,
        name: "combined-default",
        enabled: true,
        models: Models(mobileCLIP2: true, nudeNet: true),
        personDetection: PersonDetection(
            enabled: true, useFaceFallback: true, useWholeImageFallback: true,
            maximumPersonCrops: 12, horizontalCropPadding: 0.15, verticalCropPadding: 0.20
        ),
        mobileCLIP2Policy: MobileCLIP2Policy(
            womanMinScore: 0.42, womanMinMarginOverMan: 0.10,
            faceFallbackWomanMinScore: 0.48, wholeImageFallbackWomanMinScore: 0.58,
            uncertainMinScore: 0.90, blockWomanWithoutMarginIfScoreAtLeast: 0.70
        ),
        nudeNet: NudeNet(runFullImage: true, runPersonCrops: true, thresholds: [
            "FEMALE_GENITALIA_COVERED": 0.80, "FACE_FEMALE": 1.01,
            "BUTTOCKS_EXPOSED": 0.35, "FEMALE_BREAST_EXPOSED": 0.30,
            "FEMALE_GENITALIA_EXPOSED": 0.30, "MALE_BREAST_EXPOSED": 1.01,
            "ANUS_EXPOSED": 0.30, "FEET_EXPOSED": 1.01,
            "BELLY_COVERED": 1.01, "FEET_COVERED": 1.01,
            "ARMPITS_COVERED": 1.01, "ARMPITS_EXPOSED": 1.01,
            "FACE_MALE": 1.01, "BELLY_EXPOSED": 0.75,
            "MALE_GENITALIA_EXPOSED": 0.30, "ANUS_COVERED": 0.90,
            "FEMALE_BREAST_COVERED": 0.82, "BUTTOCKS_COVERED": 0.82
        ]),
        pipeline: Pipeline(
            shortCircuitOnBlock: true, maximumImageBytes: 4 * 1_024 * 1_024,
            maximumPixelDimension: 2_048, maximumTotalPixels: 12_000_000
        ),
        runtime: Runtime(
            maxConcurrentInference: 1, maxConcurrentImageInspections: 1,
            maxQueuedImageInspections: 2, inspectionQueueOverflowAction: .failOpen,
            minimumAvailableMemoryBytes: 32 * 1_024 * 1_024
        ),
        failurePolicy: FailurePolicy(
            classifierError: .failOpen, modelUnavailable: .failOpen,
            imageTooLarge: .failOpen, memoryPressure: .failOpen,
            unsupportedEncoding: .failOpen
        )
    )

    public func normalizedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func contentHash() throws -> String {
        SHA256.hash(data: try normalizedData()).map { String(format: "%02x", $0) }.joined()
    }
}

public nonisolated enum PurelineFilterConfigurationValidator {
    public static let supportedSchemaVersion = 1
    public static let maximumImageBytes = 16 * 1_024 * 1_024
    public static let maximumPixelDimension = 4_096
    public static let maximumTotalPixels = 20_000_000
    public static let maximumPersonCrops = 24
    public static let maximumConcurrency = 2
    public static let maximumQueueDepth = 8
    public static let maximumMinimumAvailableMemoryBytes: UInt64 = 512 * 1_024 * 1_024

    public struct ValidationError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
        public let path: String
        public let message: String
        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
        public var description: String { "\(path): \(message)" }
    }

    public static func decodeAndValidate(_ data: Data) throws -> PurelineFilterConfiguration {
        let configuration: PurelineFilterConfiguration
        do { configuration = try JSONDecoder().decode(PurelineFilterConfiguration.self, from: data) }
        catch { throw ValidationError(path: "$", message: "Malformed or incomplete JSON: \(error.localizedDescription)") }
        let errors = validate(configuration)
        guard errors.isEmpty else { throw errors[0] }
        return configuration
    }

    public static func validate(_ value: PurelineFilterConfiguration) -> [ValidationError] {
        var errors: [ValidationError] = []
        func require(_ condition: Bool, _ path: String, _ message: String) {
            if !condition { errors.append(ValidationError(path: path, message: message)) }
        }
        require(value.schemaVersion == supportedSchemaVersion, "schemaVersion", "Unsupported schema version")
        require(!value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.name.count <= 80,
                "name", "Must contain 1...80 characters")
        let probabilities: [(String, Double)] = [
            ("mobileCLIP2Policy.womanMinScore", value.mobileCLIP2Policy.womanMinScore),
            ("mobileCLIP2Policy.womanMinMarginOverMan", value.mobileCLIP2Policy.womanMinMarginOverMan),
            ("mobileCLIP2Policy.faceFallbackWomanMinScore", value.mobileCLIP2Policy.faceFallbackWomanMinScore),
            ("mobileCLIP2Policy.wholeImageFallbackWomanMinScore", value.mobileCLIP2Policy.wholeImageFallbackWomanMinScore),
            ("mobileCLIP2Policy.uncertainMinScore", value.mobileCLIP2Policy.uncertainMinScore),
            ("mobileCLIP2Policy.blockWomanWithoutMarginIfScoreAtLeast", value.mobileCLIP2Policy.blockWomanWithoutMarginIfScoreAtLeast)
        ] + value.nudeNet.thresholds.map { ("nudeNet.thresholds.\($0.key)", $0.value) }
        for (path, number) in probabilities { require(number.isFinite && (0...1.01).contains(number), path, "Must be in 0...1.01") }
        require(value.personDetection.maximumPersonCrops >= 0 && value.personDetection.maximumPersonCrops <= maximumPersonCrops,
                "personDetection.maximumPersonCrops", "Must be in 0...\(maximumPersonCrops)")
        require((0...0.5).contains(value.personDetection.horizontalCropPadding), "personDetection.horizontalCropPadding", "Must be in 0...0.5")
        require((0...0.5).contains(value.personDetection.verticalCropPadding), "personDetection.verticalCropPadding", "Must be in 0...0.5")
        require(value.pipeline.maximumImageBytes > 0 && value.pipeline.maximumImageBytes <= maximumImageBytes,
                "pipeline.maximumImageBytes", "Must be in 1...\(maximumImageBytes)")
        require(value.pipeline.maximumPixelDimension > 0 && value.pipeline.maximumPixelDimension <= maximumPixelDimension,
                "pipeline.maximumPixelDimension", "Must be in 1...\(maximumPixelDimension)")
        require(value.pipeline.maximumTotalPixels > 0 && value.pipeline.maximumTotalPixels <= maximumTotalPixels,
                "pipeline.maximumTotalPixels", "Must be in 1...\(maximumTotalPixels)")
        require((1...maximumConcurrency).contains(value.runtime.maxConcurrentInference), "runtime.maxConcurrentInference", "Must be in 1...\(maximumConcurrency)")
        require((1...maximumConcurrency).contains(value.runtime.maxConcurrentImageInspections), "runtime.maxConcurrentImageInspections", "Must be in 1...\(maximumConcurrency)")
        require((0...maximumQueueDepth).contains(value.runtime.maxQueuedImageInspections), "runtime.maxQueuedImageInspections", "Must be in 0...\(maximumQueueDepth)")
        require(value.runtime.minimumAvailableMemoryBytes <= maximumMinimumAvailableMemoryBytes,
                "runtime.minimumAvailableMemoryBytes", "Exceeds the hard safety ceiling")
        require(!value.models.mobileCLIP2 || value.personDetection.enabled,
                "personDetection.enabled", "Must be enabled when MobileCLIP2 is enabled")
        require(!value.nudeNet.runPersonCrops || value.personDetection.enabled,
                "personDetection.enabled", "Must be enabled for NudeNet person crops")
        require(!value.models.nudeNet || value.nudeNet.runFullImage || value.nudeNet.runPersonCrops,
                "nudeNet", "At least one NudeNet stage must be enabled")
        return errors
    }
}

public nonisolated struct PurelineFilterRevision: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var hash: String
    public var configurationName: String
    public var importedFilename: String?
    public var validatedAt: Date
    public var appliedAt: Date?

    public init(sequence: UInt64, hash: String, configurationName: String, importedFilename: String?, validatedAt: Date, appliedAt: Date? = nil) {
        self.sequence = sequence; self.hash = hash; self.configurationName = configurationName
        self.importedFilename = importedFilename; self.validatedAt = validatedAt; self.appliedAt = appliedAt
    }
}
