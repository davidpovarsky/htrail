import Foundation
import HTTrailCore
import ImageFilterCore

public struct PurelineFilterConfigurationSnapshot: Equatable, Sendable {
    public let configuration: PurelineFilterConfiguration
    public let revision: PurelineFilterRevision
}

/// App-Group-backed owner of Pureline's downstream filter policy. Invalid input
/// never reaches active.json, and every process validates active.json itself.
public final class PurelineFilterConfigurationStore: @unchecked Sendable {
    public static let shared = PurelineFilterConfigurationStore()

    public let directory: URL
    public let activeURL: URL
    public let lastGoodURL: URL
    public let revisionURL: URL
    public let acknowledgementURL: URL
    private let queue = DispatchQueue(label: "com.davidpovarsky.pureline.filter-configuration")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL = AppPaths.supportDirectory.appendingPathComponent("PurelineFilterConfiguration", isDirectory: true)) {
        self.directory = directory
        activeURL = directory.appendingPathComponent("active.json")
        lastGoodURL = directory.appendingPathComponent("last-good.json")
        revisionURL = directory.appendingPathComponent("revision.json")
        acknowledgementURL = directory.appendingPathComponent("packet-tunnel-acknowledgement.json")
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    public func install(data: Data, importedFilename: String?) throws -> PurelineFilterConfigurationSnapshot {
        let configuration = try PurelineFilterConfigurationValidator.decodeAndValidate(data)
        return try queue.sync { try installLocked(configuration, importedFilename: importedFilename) }
    }

    @discardableResult
    public func restoreDefault() throws -> PurelineFilterConfigurationSnapshot {
        try queue.sync { try installLocked(.builtIn, importedFilename: "PurelineDefaultFilterConfiguration.json") }
    }

    public func loadActive() throws -> PurelineFilterConfigurationSnapshot {
        try queue.sync {
            do { if let snapshot = try loadActiveLocked() { return snapshot } } catch {
                // A torn/external edit is never activated; recover below.
            }
            if let fallback = try loadLastGoodLocked() {
                try fallback.configuration.normalizedData().write(to: activeURL, options: .atomic)
                return fallback
            }
            return try installLocked(.builtIn, importedFilename: "PurelineDefaultFilterConfiguration.json")
        }
    }

    public func exportActive() throws -> Data { try loadActive().configuration.normalizedData() }

    public func acknowledge(_ revision: PurelineFilterRevision, appliedAt: Date = Date()) throws {
        try queue.sync {
            var applied = revision; applied.appliedAt = appliedAt
            try encoder.encode(applied).write(to: acknowledgementURL, options: .atomic)
        }
    }

    public func loadAcknowledgement() -> PurelineFilterRevision? {
        queue.sync {
            guard let data = try? Data(contentsOf: acknowledgementURL) else { return nil }
            return try? decoder.decode(PurelineFilterRevision.self, from: data)
        }
    }

    private func installLocked(_ configuration: PurelineFilterConfiguration, importedFilename: String?) throws -> PurelineFilterConfigurationSnapshot {
        if let error = PurelineFilterConfigurationValidator.validate(configuration).first { throw error }
        let data = try configuration.normalizedData()
        let prior = loadRevisionLocked()
        let revision = PurelineFilterRevision(
            sequence: (prior?.sequence ?? 0) + 1,
            hash: try configuration.contentHash(), configurationName: configuration.name,
            importedFilename: importedFilename.map(Self.safeFilename), validatedAt: Date()
        )
        // Data.write(.atomic) writes a sibling temporary file and renames it;
        // readers therefore observe either the old or complete new document.
        try data.write(to: activeURL, options: .atomic)
        try data.write(to: lastGoodURL, options: .atomic)
        let revisionData = try encoder.encode(revision)
        try revisionData.write(to: revisionURL, options: .atomic)
        let persistedRevision = try decoder.decode(PurelineFilterRevision.self, from: revisionData)
        return PurelineFilterConfigurationSnapshot(configuration: configuration, revision: persistedRevision)
    }

    private func loadActiveLocked() throws -> PurelineFilterConfigurationSnapshot? {
        guard let data = try? Data(contentsOf: activeURL), let revision = loadRevisionLocked() else { return nil }
        let configuration = try PurelineFilterConfigurationValidator.decodeAndValidate(data)
        guard try configuration.contentHash() == revision.hash else {
            throw PurelineFilterConfigurationValidator.ValidationError(path: "$", message: "Active configuration hash mismatch")
        }
        return PurelineFilterConfigurationSnapshot(configuration: configuration, revision: revision)
    }

    private func loadLastGoodLocked() throws -> PurelineFilterConfigurationSnapshot? {
        guard let data = try? Data(contentsOf: lastGoodURL) else { return nil }
        let configuration = try PurelineFilterConfigurationValidator.decodeAndValidate(data)
        let previous = loadRevisionLocked()
        let revision = PurelineFilterRevision(
            sequence: (previous?.sequence ?? 0) + 1, hash: try configuration.contentHash(),
            configurationName: configuration.name, importedFilename: previous?.importedFilename,
            validatedAt: Date()
        )
        try encoder.encode(revision).write(to: revisionURL, options: .atomic)
        return PurelineFilterConfigurationSnapshot(configuration: configuration, revision: revision)
    }

    private func loadRevisionLocked() -> PurelineFilterRevision? {
        guard let data = try? Data(contentsOf: revisionURL) else { return nil }
        return try? decoder.decode(PurelineFilterRevision.self, from: data)
    }

    private static func safeFilename(_ value: String) -> String {
        let leaf = URL(fileURLWithPath: value).lastPathComponent
        return String(leaf.filter { !$0.isNewline }.prefix(120))
    }
}
