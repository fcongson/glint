import Testing
@testable import Glint

struct LensTests {
    /// Main (1×) camera's horizontal field of view on recent iPhones, in degrees.
    private let mainFOV: Float = 69.4

    @Test(arguments: [
        (Float(108.0), 0.5, "0.5×"),   // ultra wide
        (69.4, 1, "1×"),
        (36.6, 2, "2×"),
        (28.4, 2.5, "2.5×"),
        (24.3, 3, "3×"),
        (14.8, 5, "5×"),
    ])
    func zoomSnapsToShippingFactors(fieldOfView: Float, zoom: Double, label: String) {
        let lens = Lens(id: "lens", fieldOfView: fieldOfView, mainFieldOfView: mainFOV)
        #expect(lens.zoom == zoom)
        #expect(lens.label == label)
    }

    @Test func zoomIsAlwaysAShippingFactor() {
        for fov in stride(from: Float(10), through: 120, by: 0.5) {
            let lens = Lens(id: "lens", fieldOfView: fov, mainFieldOfView: mainFOV)
            #expect(Lens.shippingZooms.contains(lens.zoom), "fov \(fov)")
        }
    }
}
