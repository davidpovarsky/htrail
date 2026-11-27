import Foundation
import ImageFilterCore

public struct PurelineInspectionAdmissionSnapshot: Equatable, Sendable {
    public let active: Int
    public let queued: Int
    public let inFlightBytes: Int
    public let inferenceActive: Int
}

/// Reserves memory before HTTrail begins buffering a response. The synchronous
/// reservation seam lets the downstream policy replace or stream a rejected
/// response before any origin bytes have reached the client.
public final class PurelineInspectionAdmissionController: @unchecked Sendable {
    public static let shared = PurelineInspectionAdmissionController()
    public static let hardInFlightByteCeiling = 16 * 1_024 * 1_024

    private struct Reservation { var bytes: Int; var active: Bool; var waiter: CheckedContinuation<Bool, Never>? }
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

    public func acquire(id: String) async -> Bool {
        let immediate = locked { reservations[id]?.active == true }
        if immediate { return true }
        return await withCheckedContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            guard var reservation = reservations[id] else { continuation.resume(returning: false); return }
            guard !reservation.active else { continuation.resume(returning: true); return }
            reservation.waiter = continuation
            reservations[id] = reservation
        }
    }

    public func release(id: String) {
        var resume: CheckedContinuation<Bool, Never>?
        lock.lock()
        let removed = reservations.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if removed?.active == true, reservations.values.filter(\.active).count < maximumActive,
           let next = order.first(where: { reservations[$0]?.active == false }), var reservation = reservations[next] {
            reservation.active = true; resume = reservation.waiter; reservation.waiter = nil; reservations[next] = reservation
        }
        lock.unlock()
        removed?.waiter?.resume(returning: false)
        resume?.resume(returning: true)
    }

    public func acquireInference() async {
        await withCheckedContinuation { continuation in
            locked {
                if inferenceActive < maximumInference {
                    inferenceActive += 1
                    continuation.resume()
                } else {
                    inferenceWaiters.append(continuation)
                }
            }
        }
    }

    public func releaseInference() {
        let continuation: CheckedContinuation<Void, Never>? = locked {
            inferenceActive = max(0, inferenceActive - 1)
            guard inferenceActive < maximumInference, !inferenceWaiters.isEmpty else { return nil }
            inferenceActive += 1
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
