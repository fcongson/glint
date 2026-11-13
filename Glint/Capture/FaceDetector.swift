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
    private var lastCount = 0          // only touched on `queue`
    private var lastTime: Double = 0   // only touched on `queue`

    static let interval = 0.5

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
        let now = CFAbsoluteTimeGetCurrent()
        guard faces.count != lastCount || now - lastTime >= Self.interval else { return }
        lastCount = faces.count
        lastTime = now
        report(faces)
    }
}
