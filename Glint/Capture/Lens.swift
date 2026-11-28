import Foundation

/// One of the back cameras, described by its zoom relative to the main (1×) camera.
struct Lens: Identifiable, Hashable, Sendable {
    let id: String  // AVCaptureDevice.uniqueID
    let zoom: Double
    /// The closest this camera focuses, in millimetres. Nil when the device doesn't say.
    let nearestMillimetres: Int?

    /// "0.5×", "1×", "3×"
    var label: String { zoom < 1 ? String(format: "%.1f×", zoom) : String(format: "%g×", zoom) }

    /// Zoom factors iPhones actually ship with. Estimates from field of view run slightly off, so they snap to these.
    static let shippingZooms: [Double] = [0.5, 1, 2, 2.5, 3, 5]

    /// Works out the zoom from horizontal fields of view in degrees (`AVCaptureDevice.Format.videoFieldOfView`).
    /// `minimumFocusDistance` is what `AVCaptureDevice.minimumFocusDistance` returns: millimetres, or -1 for unknown.
    init(id: String, fieldOfView: Float, mainFieldOfView: Float, minimumFocusDistance: Int = -1) {
        let halfTan = { (degrees: Float) in tan(Double(degrees) * .pi / 360) }
        let estimate = halfTan(mainFieldOfView) / halfTan(fieldOfView)
        self.id = id
        self.nearestMillimetres = minimumFocusDistance > 0 ? minimumFocusDistance : nil
        self.zoom = Self.shippingZooms.min { abs($0 - estimate) < abs($1 - estimate) } ?? estimate
    }
}
