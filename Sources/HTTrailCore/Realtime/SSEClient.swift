import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One parsed Server-Sent Event.
public struct SSEEvent: Sendable, Identifiable {
    public let id: UUID = UUID()
    public var event: String
    public var data: String
    public var lastEventID: String?
}

/// Streams Server-Sent Events from a URL (Hoppscotch realtime "SSE" tab),
/// parsing the `text/event-stream` line protocol.
public struct SSEClient: Sendable {
    public init() {}

    public func connect(to url: URL, headers: [String: String] = [:]) -> AsyncThrowingStream<SSEEvent, Error> {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    var eventType = "message"
                    var dataLines: [String] = []
                    var lastID: String?
                    var lineBytes: [UInt8] = []

                    // NOTE: we parse the raw byte stream rather than `bytes.lines`
                    // because Foundation's `AsyncLineSequence` skips *empty* lines,
                    // and SSE uses the blank line between fields to delimit events.
                    for try await byte in bytes {
                        guard byte == UInt8(ascii: "\n") else { lineBytes.append(byte); continue }
                        if lineBytes.last == UInt8(ascii: "\r") { lineBytes.removeLast() }
                        let line = String(decoding: lineBytes, as: UTF8.self)
                        lineBytes.removeAll(keepingCapacity: true)

                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                continuation.yield(SSEEvent(event: eventType,
                                                            data: dataLines.joined(separator: "\n"),
                                                            lastEventID: lastID))
                            }
                            eventType = "message"
                            dataLines = []
                            continue
                        }
                        if line.hasPrefix(":") { continue } // comment / heartbeat
                        let (field, value) = parseField(line)
                        switch field {
                        case "event": eventType = value
                        case "data": dataLines.append(value)
                        case "id": lastID = value
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func parseField(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }
}
