import Foundation
import ImageFilterCore

public nonisolated struct PurelineInspectionAdmissionSnapshot: Equatable, Sendable {
    public let active: Int
    public let queued: Int
    public let inFlightBytes: Int
    public let inferenceActive: Int
}

/// Reserves memory before HTTrail begins buffering a response. The synchronous
/// reservation seam is intentional: a rejected response streams transparently.
public final class PurelineInspectionAdmissionController: @unchecked Sendable {
    public static let shared = PurelineInspectionAdmissionController()
    public static let hardInFlightByteCeiling = 16 * 1_024 * 1_024

    private struct Reservation { var bytes: Int; var active: Bool; var waiter: CheckedContinuation<Void, Never>? }
    private let lock = NSLock()
    private var reservations: [String: Reservation] = [:]
    private var order: [String] = []
    private var maximumActive = 1
    private var maximumQueued = 2
    private var maximumImageBytes = 4 * 1_024 * 1_024
    private var maximumInference = 1
    private var inferenceActive = 0
    private var inferenceWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func apply(_ config: PurelineFilterConfiguration.Runtime, maximumImageBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        maximumActive = config.maxConcurrentImageInspections
        maximumQueued = config.maxQueuedImageInspections
        maximumInference = config.maxConcurrentInference
        self.maximumImageBytes = maximumImageBytes
    }

    public func tryReserve(id: String, bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard reservations[id] == nil, bytes > 0, bytes <= maximumImageBytes else { return false }
        let active = reservations.values.filter(\.active).count
        let queued = reservations.count - active
        guard active < maximumActive || queued < maximumQueued else { return false }
        let budget = min(Self.hardInFlightByteCeiling, maximumImageBytes * (maximumActive + maximumQueued))
        guard reservations.values.reduce(0, { $0 + $1.bytes }) + bytes <= budget else { return false }
        let isActive = active < maximumActive
        reservations[id] = Reservation(bytes: bytes, active: isActive, waiter: nil)
        order.append(id)
        return true
    }

    public func acquire(id: String) async {
        let immediate = locked { reservations[id]?.active == true }
        if immediate { return }
        await withCheckedContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            guard var reservation = reservations[id], !reservation.active else { continuation.resume(); return }
            reservation.waiter = continuation
            reservations[id] = reservation
        }
    }

    public func release(id: String) {
        var resume: CheckedContinuation<Void, Never>?
        lock.lock()
        let wasActive = reservations.removeValue(forKey: id)?.active == true
        order.removeAll { $0 == id }
        if wasActive, let next = order.first(where: { reservations[$0]?.active == false }), var reservation = reservations[next] {
            reservation.active = true; resume = reservation.waiter; reservation.waiter = nil; reservations[next] = reservation
        }
        lock.unlock()
        resume?.resume()
    }

    public func acquireInference() async {
        if locked({
            if inferenceActive < maximumInference { inferenceActive += 1; return true }
            return false
        }) { return }
        await withCheckedContinuation { continuation in locked { inferenceWaiters.append(continuation) } }
    }

    public func releaseInference() {
        let continuation: CheckedContinuation<Void, Never>? = locked {
            if inferenceWaiters.isEmpty { inferenceActive = max(0, inferenceActive - 1); return nil }
            return inferenceWaiters.removeFirst()
        }
        continuation?.resume()
    }

    public func snapshot() -> PurelineInspectionAdmissionSnapshot {
        locked {
            let active = reservations.values.filter(\.active).count
            return PurelineInspectionAdmissionSnapshot(
                active: active, queued: reservations.count - active,
                inFlightBytes: reservations.values.reduce(0) { $0 + $1.bytes }, inferenceActive: inferenceActive
            )
        }
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}
