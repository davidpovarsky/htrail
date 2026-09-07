import Foundation
import HTTrailCore

public struct PurelineDiagnosticEvent: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let runID: UUID
    public let category: String
    public let event: String
    public let details: [String: String]
}

/// App-Group-backed, bounded diagnostics for the Pureline Packet Tunnel.
/// Records contain only sanitized operational metadata; network payloads and
/// credential-bearing headers are never accepted by this API.
public final class PurelinePacketTunnelDiagnostics: @unchecked Sendable {
    public static let shared = PurelinePacketTunnelDiagnostics()
    public static let unexpectedTerminationMessage = "previous extension run ended unexpectedly"

    private struct RunMarker: Codable { let runID: UUID; let startedAt: Date }
    private struct State: Codable { var startCount: Int = 0 }

    private let directory: URL
    private let eventsURL: URL
    private let markerURL: URL
    private let stateURL: URL
    private let maximumEvents: Int
    private let maximumBytes: Int
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var runID = UUID()

    public init(
        directory: URL = AppPaths.supportDirectory.appendingPathComponent("PurelineDiagnostics", isDirectory: true),
        maximumEvents: Int = 400,
        maximumBytes: Int = 512 * 1024
    ) {
        self.directory = directory
        self.eventsURL = directory.appendingPathComponent("packet-tunnel-events.jsonl")
        self.markerURL = directory.appendingPathComponent("active-run.json")
        self.stateURL = directory.appendingPathComponent("state.json")
        self.maximumEvents = max(1, maximumEvents)
        self.maximumBytes = max(1024, maximumBytes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    public func beginRun() -> Int {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runID = UUID()
        if let data = try? Data(contentsOf: markerURL),
           let previous = try? decoder.decode(RunMarker.self, from: data) {
            appendLocked(category: "lifecycle", event: Self.unexpectedTerminationMessage, details: [
                "previousRunID": previous.runID.uuidString,
                "previousStartedAt": ISO8601DateFormatter().string(from: previous.startedAt)
            ])
        }
        var state = loadStateLocked()
        state.startCount += 1
        if let data = try? encoder.encode(state) { try? data.write(to: stateURL, options: .atomic) }
        let marker = RunMarker(runID: runID, startedAt: Date())
        if let data = try? encoder.encode(marker) { try? data.write(to: markerURL, options: .atomic) }
        appendLocked(category: "lifecycle", event: "extension process start", details: [
            "startCount": String(state.startCount)
        ])
        return state.startCount
    }

    public func endRun(stopReason: Int) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(category: "lifecycle", event: "extension process stop", details: [
            "NEProviderStopReason": String(stopReason)
        ])
        try? FileManager.default.removeItem(at: markerURL)
    }

    public func record(category: String, event: String, details: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(category: category, event: event, details: details)
    }

    public func events() -> [PurelineDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return readEventsLocked()
    }

    public var logURL: URL { eventsURL }

    private func appendLocked(category: String, event: String, details: [String: String]) {
        var events = readEventsLocked()
        events.append(PurelineDiagnosticEvent(
            timestamp: Date(), runID: runID,
            category: Self.sanitizeToken(category), event: Self.sanitizeText(event),
            details: details.reduce(into: [:]) { result, pair in
                let key = Self.sanitizeToken(pair.key)
                guard !Self.sensitiveKeys.contains(key.lowercased()) else { return }
                result[key] = Self.sanitizeText(pair.value)
            }
        ))
        if events.count > maximumEvents { events.removeFirst(events.count - maximumEvents) }

        while !events.isEmpty {
            let data = encodedLines(events)
            if data.count <= maximumBytes {
                try? data.write(to: eventsURL, options: .atomic)
                return
            }
            events.removeFirst()
        }
        try? Data().write(to: eventsURL, options: .atomic)
    }

    private func readEventsLocked() -> [PurelineDiagnosticEvent] {
        guard let data = try? Data(contentsOf: eventsURL) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(PurelineDiagnosticEvent.self, from: Data($0)) }
    }

    private func encodedLines(_ events: [PurelineDiagnosticEvent]) -> Data {
        var data = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            data.append(line); data.append(0x0A)
        }
        return data
    }

    private func loadStateLocked() -> State {
        guard let data = try? Data(contentsOf: stateURL) else { return State() }
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    private static let sensitiveKeys: Set<String> = [
        "authorization", "cookie", "set-cookie", "password", "token", "privatekey", "private-key", "body"
    ]

    private static func sanitizeToken(_ value: String) -> String {
        String(value.prefix(80)).replacingOccurrences(of: "\n", with: " ")
    }

    public static func sanitizeText(_ value: String) -> String {
        var output = String(value.prefix(1024))
        output = output.replacingOccurrences(
            of: #"(?i)Bearer\s+[A-Za-z0-9._~+/-]+"#, with: "Bearer <REDACTED>", options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"([?&][^=&\s]+)=([^&#\s]*)"#, with: "$1=<REDACTED>", options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?i)(authorization|cookie|password|token)\s*[:=]\s*[^\s,;]+"#,
            with: "$1=<REDACTED>", options: .regularExpression
        )
        return output.replacingOccurrences(of: "\n", with: " ")
    }
}
