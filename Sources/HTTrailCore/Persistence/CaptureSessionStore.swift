import Foundation

/// Persists capture sessions: metadata in `sessions/index.json` (newest-first)
/// and each session's flows in a sibling `<uuid>.ndjson` (one JSON `Flow` per
/// line, upserted by `flow.id` — a flow appears `.pending` then `.completed`).
/// The app process is the sole writer on both platforms. Mirrors the in-memory
/// order/byID upsert strategy of `SharedFlowStore`, but keyed per session.
public final class CaptureSessionStore: @unchecked Sendable {
    private let directory: URL
    private let indexURL: URL
    private let capacityPerSession: Int
    private let queue = DispatchQueue(label: "com.httrail.sessionstore")
    private var caches: [UUID: (order: [UUID], byID: [UUID: Flow])] = [:]

    public init(directory: URL = AppPaths.supportDirectory.appendingPathComponent("sessions", isDirectory: true),
                capacityPerSession: Int = 10_000) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.indexURL = directory.appendingPathComponent("index.json")
        self.capacityPerSession = capacityPerSession
    }

    // MARK: - Index

    public func allSessions() -> [CaptureSession] { queue.sync { loadIndexLocked() } }

    private func loadIndexLocked() -> [CaptureSession] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([CaptureSession].self, from: data)) ?? []
    }

    private func saveIndexLocked(_ sessions: [CaptureSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func mutateSessionLocked(_ id: UUID, _ change: (inout CaptureSession) -> Void) {
        var sessions = loadIndexLocked()
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
        saveIndexLocked(sessions)
    }

    @discardableResult
    public func createSession(name: String, startedAt: Date) -> CaptureSession {
        queue.sync {
            var sessions = loadIndexLocked()
            let session = CaptureSession(name: name, startedAt: startedAt)
            sessions.insert(session, at: 0)
            saveIndexLocked(sessions)
            return session
        }
    }

    public func rename(_ id: UUID, to name: String) { queue.sync { mutateSessionLocked(id) { $0.name = name } } }
    public func setNotes(_ id: UUID, _ notes: String) { queue.sync { mutateSessionLocked(id) { $0.notes = notes } } }
    public func reopen(_ id: UUID) { queue.sync { mutateSessionLocked(id) { $0.endedAt = nil } } }
    public func endSession(_ id: UUID, at endedAt: Date) { queue.sync { mutateSessionLocked(id) { $0.endedAt = endedAt } } }

    public func deleteSession(_ id: UUID) {
        queue.sync {
            caches[id] = nil
            try? FileManager.default.removeItem(at: fileURL(id))
            var sessions = loadIndexLocked()
            sessions.removeAll { $0.id == id }
            saveIndexLocked(sessions)
        }
    }

    // MARK: - Flows

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).ndjson") }

    private func ensureCacheLocked(_ id: UUID) {
        if caches[id] != nil { return }
        var order: [UUID] = []
        var byID: [UUID: Flow] = [:]
        if let data = try? Data(contentsOf: fileURL(id)), !data.isEmpty {
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let flow = try? decoder.decode(Flow.self, from: Data(line)) {
                    if byID[flow.id] == nil { order.append(flow.id) }
                    byID[flow.id] = flow
                }
            }
        }
        caches[id] = (order, byID)
    }

    private func persistFlowsLocked(_ id: UUID) {
        guard let cache = caches[id] else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for fid in cache.order {
            guard let flow = cache.byID[fid], let line = try? encoder.encode(flow) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: fileURL(id), options: .atomic)
    }

    public func record(_ flow: Flow, in id: UUID) {
        queue.sync {
            ensureCacheLocked(id)
            var cache = caches[id]!
            if cache.byID[flow.id] == nil {
                cache.order.append(flow.id)
                if cache.order.count > capacityPerSession, let evicted = cache.order.first {
                    cache.order.removeFirst()
                    cache.byID[evicted] = nil
                }
            }
            cache.byID[flow.id] = flow
            caches[id] = cache
            persistFlowsLocked(id)
            mutateSessionLocked(id) { $0.recordCount = cache.order.count }
        }
    }

    /// Current flow count for a session — cheap (reads the in-memory cache).
    public func flowCount(in id: UUID) -> Int {
        queue.sync { ensureCacheLocked(id); return caches[id]?.order.count ?? 0 }
    }

    public func deleteFlows(_ ids: Set<UUID>, in id: UUID) {
        queue.sync {
            ensureCacheLocked(id)
            var cache = caches[id]!
            cache.order.removeAll { ids.contains($0) }
            for fid in ids { cache.byID[fid] = nil }
            caches[id] = cache
            persistFlowsLocked(id)
            mutateSessionLocked(id) { $0.recordCount = cache.order.count }
        }
    }

    /// All flows in the session, newest-first (matching the in-app list order).
    public func flows(in id: UUID) -> [Flow] {
        queue.sync {
            ensureCacheLocked(id)
            let cache = caches[id]!
            return cache.order.compactMap { cache.byID[$0] }.reversed()
        }
    }
}
