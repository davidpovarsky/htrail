import Foundation

/// Bridges captured flows across the process boundary between the iOS Packet
/// Tunnel extension (which runs the proxy in the background) and the app (which
/// renders them). The extension writes; the app reads. Backed by a single
/// newline-delimited-JSON file in the shared App Group container.
///
/// Flows are keyed by `id`: a flow appears first as `.pending`, then again as
/// `.completed`, so writes replace the prior entry for that id. The store is
/// bounded to `capacity` most-recent flows so the file can't grow without limit.
public final class SharedFlowStore: @unchecked Sendable {
    private let url: URL
    private let capacity: Int
    private let queue = DispatchQueue(label: "com.httrail.sharedflowstore")
    private var order: [UUID] = []
    private var byID: [UUID: Flow] = [:]

    public init?(capacity: Int = 500) {
        guard let url = AppGroup.capturedFlowsURL() else { return nil }
        self.url = url
        self.capacity = capacity
    }

    /// Test/explicit-path initialiser (also used when no App Group is present).
    public init(url: URL, capacity: Int = 500) {
        self.url = url
        self.capacity = capacity
    }

    // MARK: - Writer (extension side)

    /// Upserts a flow and rewrites the shared file atomically.
    public func record(_ flow: Flow) {
        queue.sync {
            if byID[flow.id] == nil {
                order.append(flow.id)
                if order.count > capacity, let evicted = order.first {
                    order.removeFirst()
                    byID[evicted] = nil
                }
            }
            byID[flow.id] = flow
            persistLocked()
        }
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        var data = Data()
        for id in order {
            guard let flow = byID[id], let line = try? encoder.encode(flow) else { continue }
            data.append(line)
            data.append(0x0A) // \n
        }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Reader (app side)

    /// Reads all currently-shared flows, newest first (matching the in-app list).
    public func readAll() -> [Flow] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        var result: [Flow] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let flow = try? decoder.decode(Flow.self, from: Data(line)) {
                result.append(flow)
            }
        }
        return result.reversed()
    }

    /// Clears the shared file (used by the app's "Clear" action).
    public func clear() {
        queue.sync {
            order.removeAll(); byID.removeAll()
            try? Data().write(to: url, options: .atomic)
        }
    }
}

/// `FlowSink` adapter so `ProxyServer` in the extension can emit straight into
/// the shared store.
public final class SharedFlowSink: FlowSink, @unchecked Sendable {
    private let store: SharedFlowStore
    public init(store: SharedFlowStore) { self.store = store }
    public func record(_ flow: Flow) { store.record(flow) }
}
