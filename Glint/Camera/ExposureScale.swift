import Foundation

/// The discrete stops the manual-control rulers step through, and which of them count as full stops.
/// Pure values with no device or UI state; the device clamps anything its active format can't reach.
enum ExposureScale {
    /// Shutter speeds as 1/x seconds, in conventional 1/3-stop steps.
    static let shutterDenominators: [Double] = [8, 10, 13, 15, 20, 25, 30, 40, 50, 60, 80, 100, 125, 160, 200, 250, 320,
                                                400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000]

    /// ISO in conventional 1/3-stop steps. Use `isoStops(min:max:)` for the range a lens can actually reach.
    static let allISOStops: [Float] = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600,
                                       2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25000, 32000, 40000, 50000]

    /// White balance runs 2000–10000K in 100K steps.
    static let whiteBalanceKelvins: [Float] = stride(from: 2000, through: 10000, by: 100).map { Float($0) }

    static let whiteBalancePresets: [(name: String, kelvin: Float)] = [
        ("Tungsten", 3200), ("Fluor.", 4000), ("Daylight", 5500), ("Flash", 5600), ("Cloudy", 6500), ("Shade", 7500)
    ]

    /// The ISO stops within a lens's range. Never empty: falls back to the minimum if no conventional stop fits.
    static func isoStops(min: Float, max: Float) -> [Float] {
        let stops = allISOStops.filter { $0 >= min && $0 <= max }
        return stops.isEmpty ? [min] : stops
    }

    /// The series starts on a full stop (1/8) with three steps per stop.
    static func isFullStopShutter(index: Int) -> Bool { index % 3 == 0 }

    /// 50, 100, 200, 400 …
    static func isFullStopISO(_ iso: Float) -> Bool {
        let stops = log2(Double(iso) / 100)
        return abs(stops - stops.rounded()) < 0.1
    }

    /// Every 1000K.
    static func isMajorWhiteBalance(_ kelvin: Float) -> Bool { Int(kelvin) % 1000 == 0 }

    /// Stops are ascending. A value exactly half-way between two stops goes to the higher one, like ordinary rounding.
    static func nearestIndex<T: BinaryFloatingPoint>(of value: T, in stops: [T]) -> Int {
        var best = 0
        for i in stops.indices where abs(stops[i] - value) <= abs(stops[best] - value) {
            best = i
        }
        return best
    }

    static func nearest<T: BinaryFloatingPoint>(_ value: T, in stops: [T]) -> T {
        stops.isEmpty ? value : stops[nearestIndex(of: value, in: stops)]
    }
}
