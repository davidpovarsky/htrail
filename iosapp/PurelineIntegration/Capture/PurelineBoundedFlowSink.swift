import Foundation
import HTTrailCore

public struct PurelineCaptureLimits: Sendable, Equatable {
    public var requestPreviewBytes: Int
    public var responsePreviewBytes: Int
    public var totalBodyBytes: Int
    public var flowCount: Int

    public init(
        requestPreviewBytes: Int = 256 * 1024,
        responsePreviewBytes: Int = 512 * 1024,
        totalBodyBytes: Int = 8 * 1024 * 1024,
        flowCount: Int = 200
    ) {
        self.requestPreviewBytes = max(0, requestPreviewBytes)
        self.responsePreviewBytes = max(0, responsePreviewBytes)
        self.totalBodyBytes = max(0, totalBodyBytes)
        self.flowCount = max(1, flowCount)
    }

    public static let packetTunnel = PurelineCaptureLimits()
}

public struct PurelineCaptureSnapshot: Sendable, Equatable {
    public let flowCount: Int
    public let retainedBodyBytes: Int
    public let truncatedRequestCount: Int
    public let truncatedResponseCount: Int
}

/// Pureline-only capture sink. It never changes bytes on the network; it trims
/// only copies retained for diagnostics/UI and evicts the oldest retained bodies
/// before the configured aggregate budget can be exceeded.
public final class PurelineBoundedFlowSink: FlowSink, @unchecked Sendable {
    private let limits: PurelineCaptureLimits
    private let store: SharedFlowStore?
    private let lock = NSLock()
    private var order: [UUID] = []
    private var flows: [UUID: Flow] = [:]
    private var retainedBodyBytes = 0
    private var truncatedRequestCount = 0
    private var truncatedResponseCount = 0
    public var onSnapshot: (@Sendable (PurelineCaptureSnapshot) -> Void)?

    public init(limits: PurelineCaptureLimits, store: SharedFlowStore?) {
        self.limits = limits
        self.store = store
    }

    public convenience init?(limits: PurelineCaptureLimits = .packetTunnel) {
        guard let store = SharedFlowStore(capacity: limits.flowCount) else { return nil }
        self.init(limits: limits, store: store)
    }

    public func record(_ flow: Flow) {
        lock.lock(); defer { lock.unlock() }
        var bounded = bound(flow)
        if let old = flows[bounded.id] { retainedBodyBytes -= bodyBytes(old) }
        else { order.append(bounded.id) }
        flows[bounded.id] = bounded
        retainedBodyBytes += bodyBytes(bounded)

        while order.count > limits.flowCount, let id = order.first {
            order.removeFirst()
            if let removed = flows.removeValue(forKey: id) { retainedBodyBytes -= bodyBytes(removed) }
        }

        for id in order where retainedBodyBytes > limits.totalBodyBytes {
            guard id != bounded.id, var old = flows[id] else { continue }
            retainedBodyBytes -= bodyBytes(old)
            truncateAllBodies(&old)
            flows[id] = old
            retainedBodyBytes += bodyBytes(old)
            store?.record(old)
        }
        if retainedBodyBytes > limits.totalBodyBytes {
            let allowed = max(0, limits.totalBodyBytes - (retainedBodyBytes - bodyBytes(bounded)))
            bounded = fit(bounded, within: allowed)
            retainedBodyBytes -= bodyBytes(flows[bounded.id]!)
            flows[bounded.id] = bounded
            retainedBodyBytes += bodyBytes(bounded)
        }
        store?.record(bounded)
        onSnapshot?(snapshotLocked())
    }

    public func snapshot() -> PurelineCaptureSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }

    public func retainedFlowsNewestFirst() -> [Flow] {
        lock.lock(); defer { lock.unlock() }
        return order.reversed().compactMap { flows[$0] }
    }

    private func bound(_ flow: Flow) -> Flow {
        var result = flow
        if result.request.body.count > limits.requestPreviewBytes {
            result.request.body = Data(result.request.body.prefix(limits.requestPreviewBytes))
            result.request.bodyTruncated = true
            truncatedRequestCount += 1
        }
        if var response = result.response, response.body.count > limits.responsePreviewBytes {
            response.body = Data(response.body.prefix(limits.responsePreviewBytes))
            response.bodyTruncated = true
            result.response = response
            truncatedResponseCount += 1
        }
        return result
    }

    private func fit(_ flow: Flow, within budget: Int) -> Flow {
        var result = flow
        var remaining = budget
        if result.request.body.count > remaining {
            result.request.body = Data(result.request.body.prefix(remaining)); result.request.bodyTruncated = true
        }
        remaining -= result.request.body.count
        if var response = result.response, response.body.count > remaining {
            response.body = Data(response.body.prefix(remaining)); response.bodyTruncated = true; result.response = response
        }
        return result
    }

    private func truncateAllBodies(_ flow: inout Flow) {
        if !flow.request.body.isEmpty { flow.request.body = Data(); flow.request.bodyTruncated = true }
        if var response = flow.response, !response.body.isEmpty {
            response.body = Data(); response.bodyTruncated = true; flow.response = response
        }
        if flow.webSocketMessages != nil {
            flow.webSocketMessages = flow.webSocketMessages?.map {
                WebSocketMessage(id: $0.id, direction: $0.direction, kind: $0.kind,
                                 data: Data(), timestamp: $0.timestamp, truncated: true)
            }
        }
    }

    private func bodyBytes(_ flow: Flow) -> Int {
        flow.request.body.count + (flow.response?.body.count ?? 0)
            + (flow.webSocketMessages?.reduce(0) { $0 + $1.data.count } ?? 0)
    }

    private func snapshotLocked() -> PurelineCaptureSnapshot {
        PurelineCaptureSnapshot(
            flowCount: flows.count, retainedBodyBytes: retainedBodyBytes,
            truncatedRequestCount: truncatedRequestCount,
            truncatedResponseCount: truncatedResponseCount
        )
    }
}
