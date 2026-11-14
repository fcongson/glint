import AVFoundation

/// Receives the faces the camera finds, for VoiceOver's description of the picture. The camera hardware does the
/// detecting; `CaptureSession` attaches `output` only while VoiceOver is running, so it costs nothing otherwise.
///
/// Reports at most twice a second, and at once when the number of faces changes (including to none). Frames are in
/// the metadata output's coordinates; the controller turns them into the picture's.
final class FaceDetector: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let output = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "glint.faces")
    private let report: @Sendable ([CGRect]) -> Void
    private var pacer = FaceReportPacer()   // only touched on `queue`

    init(report: @escaping @Sendable ([CGRect]) -> Void) {
        self.report = report
        super.init()
        output.setMetadataObjectsDelegate(self, queue: queue)
    }

    /// Which metadata the output can report depends on the lens and format, so this runs after each change of
    /// either. Where faces aren't on offer (some video formats), it reports nothing.
    func selectFaces() {
        let types: [AVMetadataObject.ObjectType] = output.availableMetadataObjectTypes.contains(.face) ? [.face] : []
        if output.metadataObjectTypes != types { output.metadataObjectTypes = types }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        let faces = metadataObjects.filter { $0.type == .face }.map(\.bounds)
        if pacer.shouldReport(count: faces.count, now: CFAbsoluteTimeGetCurrent()) { report(faces) }
    }
}

/// When to pass the camera's faces on: at once when their number changes (including to none, which the camera
/// says only once), otherwise at most every `interval`, which is enough to follow a face across the picture.
struct FaceReportPacer: Sendable {
    static let interval = 0.5

    private var lastCount = 0
    private var lastTime = -Double.infinity

    mutating func shouldReport(count: Int, now: Double) -> Bool {
        guard count != lastCount || now - lastTime >= Self.interval else { return false }
        lastCount = count
        lastTime = now
        return true
    }
}
