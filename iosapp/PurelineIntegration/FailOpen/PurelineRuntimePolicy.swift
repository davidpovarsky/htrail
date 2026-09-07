import Darwin
import Foundation

/// One downstream availability policy for PacketTunnel inspection failures.
/// Every outcome here preserves network bytes and sacrifices only inspection or
/// capture completeness.
public enum PurelineRuntimePolicy {
    public static let requestPreviewBytes = 256 * 1024
    public static let responsePreviewBytes = 512 * 1024
    public static let totalCaptureBodyBytes = 8 * 1024 * 1024
    public static let recentFlowCount = 200
    public static let requestInspectionBytes = 1024 * 1024
    public static let imageInspectionBytes = 4 * 1024 * 1024
    public static let compatibilityBypassTTL: TimeInterval = 24 * 60 * 60
    public static let minimumAvailableMemoryForInspection: UInt64 = 32 * 1024 * 1024
    public static let classifierConcurrency = 1

    public enum InspectionDisposition: Sendable, Equatable { case inspect, passThrough }

    public static func imageDisposition(
        contentLength: Int?, availableMemoryBytes: UInt64 = currentAvailableMemoryBytes()
    ) -> InspectionDisposition {
        if let contentLength, contentLength > imageInspectionBytes { return .passThrough }
        if availableMemoryBytes > 0 && availableMemoryBytes < minimumAvailableMemoryForInspection {
            return .passThrough
        }
        return .inspect
    }

    public static func currentAvailableMemoryBytes() -> UInt64 {
        UInt64(os_proc_available_memory())
    }
}
