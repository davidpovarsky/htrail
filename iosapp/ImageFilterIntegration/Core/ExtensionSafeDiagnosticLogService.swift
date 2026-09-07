import Foundation
import OSLog

/// PacketTunnel-safe implementation of the diagnostic surface used by the
/// original classifier pipeline. The app target continues to compile and use the
/// vendor app's full DiagnosticLogService; only ImageFilterCore substitutes this
/// implementation because UIApplication is unavailable to app extensions.
actor DiagnosticLogService {
    static let shared = DiagnosticLogService()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.davidpovarsky.httrail.PacketTunnel",
        category: "image-filter"
    )

    func log(
        level: String,
        category: String,
        event: String,
        details: [String: String] = [:]
    ) async throws {
        let suffix = details.isEmpty
            ? ""
            : " " + details.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(Self.redact($0.value))" }
                .joined(separator: " ")
        let message = "[\(category)] \(event)\(suffix)"
        switch level.lowercased() {
        case "error": Self.logger.error("\(message, privacy: .public)")
        case "warning": Self.logger.warning("\(message, privacy: .public)")
        default: Self.logger.info("\(message, privacy: .public)")
        }
    }

    func recordLoadAttempts(_ attempts: [ModelLoadAttempt]) throws {
        Self.logger.info("model load attempts=\(attempts.count, privacy: .public)")
    }

    func appendInference<T: Encodable>(_ value: T) throws {
        _ = value
    }

    func appendImageSafety(_ response: ImageSafetyResponse) throws {
        Self.logger.info(
            "image safety request=\(response.requestId, privacy: .public) status=\(response.pipeline.status.rawValue, privacy: .public)"
        )
    }

    nonisolated static func flattenedErrors(_ error: Error, maximumDepth: Int = 8) -> [DiagnosticError] {
        var result: [DiagnosticError] = []
        func visit(_ current: Error, depth: Int) {
            guard depth < maximumDepth else { return }
            let ns = current as NSError
            result.append(DiagnosticError(
                domain: ns.domain,
                code: ns.code,
                description: ns.localizedDescription,
                failureReason: ns.localizedFailureReason,
                recoverySuggestion: ns.localizedRecoverySuggestion,
                userInfo: ns.userInfo.reduce(into: [:]) {
                    $0[String(describing: $1.key)] = redact(String(describing: $1.value))
                }
            ))
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
                visit(underlying, depth: depth + 1)
            }
            if let multiple = ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] {
                multiple.forEach { visit($0, depth: depth + 1) }
            }
        }
        visit(error, depth: 0)
        return result
    }

    nonisolated static func redact(_ value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"(?i)Bearer\s+[A-Za-z0-9._~+/-]+"#,
            with: "Bearer <REDACTED>",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"/Bundle/Application/[0-9A-Fa-f-]+/"#,
            with: "/Bundle/Application/<APP_CONTAINER>/",
            options: .regularExpression
        )
        return result
    }
}
