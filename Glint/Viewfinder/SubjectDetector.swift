import CoreVideo
import Vision

/// Finds people's bodies in a preview frame, for subject autofocus (the camera's face detection covers faces).
/// Called by `FrameAnalyzer` on its queue, a few times a second at most, on the small preview-sized frames.
final class SubjectDetector {
    /// At least this many seconds between looks.
    static let interval = 0.33
    static let minimumConfidence: Float = 0.5

    private let request: VNDetectHumanRectanglesRequest

    init() {
        request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false  // a person across the garden, not just one filling the frame
    }

    /// Bodies in a frame from the camera, which is turned clockwise by `angle` degrees from upright.
    func bodies(in frame: CVPixelBuffer, angle: Int) -> [SubjectCandidate] {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: Self.orientation(angle: angle))
        guard (try? handler.perform([request])) != nil, let found = request.results else { return [] }
        return
            found
            .filter { $0.confidence >= Self.minimumConfidence }
            .map { SubjectGeometry.body(visionBox: $0.boundingBox, angle: angle) }
            .filter { $0.area >= SubjectGeometry.minimumArea }
    }

    /// How Vision should turn the camera's frame to see it upright.
    static func orientation(angle: Int) -> CGImagePropertyOrientation {
        switch ((angle % 360) + 360) % 360 {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
    }
}
