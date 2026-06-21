import Foundation

/// A named set of `{{variables}}` (Hoppscotch environments).
public struct RequestEnvironment: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var variables: [KeyValueItem]

    public init(id: UUID = UUID(), name: String, variables: [KeyValueItem] = []) {
        self.id = id; self.name = name; self.variables = variables
    }

    /// Resolved dictionary of enabled variables.
    public var resolved: [String: String] {
        var result: [String: String] = [:]
        for item in variables where item.enabled && !item.name.isEmpty {
            result[item.name] = item.value
        }
        return result
    }
}

/// A folder of requests + nested folders (Hoppscotch collections).
public struct RequestCollection: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var requests: [APIRequest]
    public var folders: [RequestCollection]

    public init(id: UUID = UUID(), name: String, requests: [APIRequest] = [],
                folders: [RequestCollection] = []) {
        self.id = id; self.name = name; self.requests = requests; self.folders = folders
    }
}

/// One past send, kept in the history list.
public struct HistoryEntry: Codable, Identifiable, Sendable {
    public var id: UUID
    public var request: APIRequest
    public var statusCode: Int
    public var durationMS: Int
    public var timestamp: Date

    public init(id: UUID = UUID(), request: APIRequest, statusCode: Int,
                durationMS: Int, timestamp: Date) {
        self.id = id; self.request = request; self.statusCode = statusCode
        self.durationMS = durationMS; self.timestamp = timestamp
    }
}

/// Aggregates the persisted user data and saves it back to disk.
public final class Workspace: @unchecked Sendable {
    private let store: JSONStore
    private let lock = NSLock()

    public private(set) var collections: [RequestCollection]
    public private(set) var environments: [RequestEnvironment]
    public private(set) var history: [HistoryEntry]
    public var activeEnvironmentID: UUID?

    public init(store: JSONStore = JSONStore()) {
        self.store = store
        self.collections = store.load([RequestCollection].self, from: "collections") ?? []
        self.environments = store.load([RequestEnvironment].self, from: "environments") ?? []
        self.history = store.load([HistoryEntry].self, from: "history") ?? []
        self.activeEnvironmentID = environments.first?.id
    }

    public var activeEnvironment: RequestEnvironment? {
        environments.first { $0.id == activeEnvironmentID }
    }

    public var resolvedEnvironment: [String: String] {
        activeEnvironment?.resolved ?? [:]
    }

    // MARK: Mutations (persist immediately)

    public func setCollections(_ value: [RequestCollection]) {
        lock.lock(); collections = value; lock.unlock()
        store.save(value, to: "collections")
    }

    public func setEnvironments(_ value: [RequestEnvironment]) {
        lock.lock(); environments = value; lock.unlock()
        store.save(value, to: "environments")
    }

    public func addHistory(_ entry: HistoryEntry, limit: Int = 200) {
        lock.lock()
        history.insert(entry, at: 0)
        if history.count > limit { history = Array(history.prefix(limit)) }
        let snapshot = history
        lock.unlock()
        store.save(snapshot, to: "history")
    }

    public func clearHistory() {
        lock.lock(); history = []; lock.unlock()
        store.save([HistoryEntry](), to: "history")
    }
}
