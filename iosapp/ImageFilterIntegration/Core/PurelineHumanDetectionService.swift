import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// Downstream compute-device policy; the vendor detector and UI keep their
/// defaults. On iOS 27 the same image fails Vision's automatic inference
/// context but succeeds with its advertised CPU device. Request revisions,
/// observation mapping, and face-crop expansion remain unchanged.
nonisolated struct PurelineHumanDetectionService: Sendable {
    enum ConfigurationError: Error {
        case missingMainComputeStage
        case cpuDeviceUnavailable(computeStage: String)
    }

    private let upstream = HumanDetectionService()

    func makeHumanRequest() throws -> VNDetectHumanRectanglesRequest {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        try configureComputeDevices(request)
        return request
    }

    func makeFaceRequest() throws -> VNDetectFaceRectanglesRequest {
        let request = VNDetectFaceRectanglesRequest()
        try configureComputeDevices(request)
        return request
    }

    private func configureComputeDevices(_ request: VNRequest) throws {
        guard #available(iOS 27.0, *) else { return }
        let supported = try request.supportedComputeStageDevices
        guard supported[.main] != nil else { throw ConfigurationError.missingMainComputeStage }
        for (stage, devices) in supported {
            guard let cpu = devices.first(where: {
                if case .cpu = $0 { return true }
                return false
            }) else {
                throw ConfigurationError.cpuDeviceUnavailable(computeStage: String(describing: stage))
            }
            request.setComputeDevice(cpu, for: stage)
        }
    }

    func detect(in image: CGImage, orientation: CGImagePropertyOrientation) throws -> [HumanDetection] {
        guard #available(iOS 27.0, *) else { return try upstream.detect(in: image, orientation: orientation) }
        let request = try makeHumanRequest()
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return (request.results ?? []).map {
            HumanDetection(id: UUID(), confidence: $0.confidence,
                           boundingBox: $0.boundingBox, source: .humanRectangle)
        }
    }

    func detectFaces(in image: CGImage, orientation: CGImagePropertyOrientation) throws -> [HumanDetection] {
        guard #available(iOS 27.0, *) else { return try upstream.detectFaces(in: image, orientation: orientation) }
        let request = try makeFaceRequest()
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return (request.results ?? []).map { observation in
            let face = observation.boundingBox
            let expanded = CGRect(
                x: face.minX - face.width * 0.75,
                y: face.minY - face.height * 3.5,
                width: face.width * 2.5,
                height: face.height * 5
            ).clampedToUnitSquare
            return HumanDetection(id: UUID(), confidence: observation.confidence,
                                  boundingBox: expanded, source: .faceFallback)
        }
    }
}
