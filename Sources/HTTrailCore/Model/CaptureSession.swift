import Foundation

/// One named capture run. Persisted in `sessions/index.json`; its flows live in
/// a sibling `<id>.ndjson`. `recordCount` is cached so the sessions list can show
/// counts without reading every flow file.
public struct CaptureSession: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var notes: String
    public var startedAt: Date
    /// nil while the session is actively recording.
    public var endedAt: Date?
    public var recordCount: Int

    public init(id: UUID = UUID(), name: String, notes: String = "",
                startedAt: Date, endedAt: Date? = nil, recordCount: Int = 0) {
        self.id = id
        self.name = name
        self.notes = notes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recordCount = recordCount
    }

    public var isRecording: Bool { endedAt == nil }

    /// The default `Capture YYYY-MM-DD HH:mm:ss` name for a new session.
    public static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "Capture " + formatter.string(from: date)
    }
}
